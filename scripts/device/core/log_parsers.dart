// Parsers for what a device says about a run: logcat, `dumpsys`, `/proc/<pid>/maps`, Gradle's
// dependency report, the merged manifest, the VERIFY lines the verification app prints. Pure functions
// over text, so every assertion the harness makes has a test that shows it can FAIL (workbook 9.2: a
// check that cannot fail is not evidence).
import 'dart:convert';

import 'zip.dart';

/// The SDK's own banner: Android `Bugsee Android SDK 7.4.2 [3b7af6371]`, iOS
/// `Bugsee IOS SDK ver:7.0.0-beta7 build:...`.
class SdkBanner {
  const SdkBanner(this.platform, this.version, this.build);
  final String platform;
  final String version;
  final String build;

  @override
  String toString() => 'Bugsee $platform SDK $version [$build]';
}

SdkBanner? parseAndroidBanner(String log) {
  final m = RegExp(
    r'Bugsee Android SDK (\S+) \[([0-9a-f]+)\]',
  ).allMatches(log).lastOrNull;
  return m == null ? null : SdkBanner('android', m.group(1)!, m.group(2)!);
}

SdkBanner? parseIosBanner(String log) {
  final m = RegExp(
    r'Bugsee IOS SDK ver:(\S+) build:(\S+)',
  ).allMatches(log).lastOrNull;
  return m == null ? null : SdkBanner('ios', m.group(1)!, m.group(2)!);
}

/// What the wrapper said when it registered (before the SDK launched) and when Dart refined it.
class WrapperLog {
  const WrapperLog({this.registered, this.refined, this.context = const {}});

  /// `type/version` of `wrapper registered`.
  final String? registered;

  /// `type/version` of `wrapper refined`.
  final String? refined;
  final Map<String, String> context;
}

WrapperLog parseWrapperLog(String log) {
  String? registered;
  String? refined;
  var context = <String, String>{};
  for (final m in RegExp(
    r'wrapper registered type=(\S+) version=(\S+)',
  ).allMatches(log)) {
    registered = '${m.group(1)}/${m.group(2)}';
  }
  // Android: `context={dart=3.11.0, flutter=3.41.0}`; iOS prints the NSDictionary:
  // `context={\n    "build-configuration" = debug;\n    dart = "3.11.0";\n }`.
  for (final m in RegExp(
    r'wrapper refined type=(\S+) version=(\S+) context=\{([^}]*)\}',
  ).allMatches(log)) {
    refined = '${m.group(1)}/${m.group(2)}';
    final body = m.group(3)!;
    context = body.contains(';')
        ? {
            for (final pair in RegExp(
              r'"?([\w.-]+)"?\s*=\s*"?([^";\n]*)"?\s*;',
            ).allMatches(body))
              pair.group(1)!: pair.group(2)!.trim(),
          }
        : {
            for (final pair in body.split(', '))
              if (pair.contains('='))
                pair.substring(0, pair.indexOf('=')): pair.substring(
                  pair.indexOf('=') + 1,
                ),
          };
  }
  return WrapperLog(registered: registered, refined: refined, context: context);
}

/// The DISTINCT `libbugsee*.so` names in [text] (workbook 1.4.2: distinct, not occurrences).
Set<String> distinctBugseeLibs(String text) => {
  for (final m in RegExp(r'libbugsee[a-z-]*\.so').allMatches(text)) m.group(0)!,
};

/// A library mapped from inside an APK (stored uncompressed): `/proc/<pid>/maps` shows `base.apk` and
/// the file offset, not the library's name. Resolves each mapped offset against [apkEntries] and returns
/// the names of the `libbugsee*.so` that are mapped. Only lines mapping [apkPath] (`pm path`) count.
Set<String> mappedBugseeLibs(
  String maps,
  List<ZipEntry> apkEntries,
  String abi, {
  required String apkPath,
}) {
  final libs = [
    for (final e in apkEntries)
      if (e.isStored &&
          e.name.startsWith('lib/$abi/libbugsee') &&
          e.name.endsWith('.so'))
        e,
  ];
  final found = <String>{};
  for (final line in const LineSplitter().convert(maps)) {
    // 76c83c5000-76c8583000 r-xp 023f8000 fd:04 40963  /data/app/.../base.apk
    final m = RegExp(
      r'^[0-9a-f]+-[0-9a-f]+\s+\S+\s+([0-9a-f]+)\s+\S+\s+\d+\s+(\S.*?)\s*$',
    ).firstMatch(line);
    // Only the package's own APK: another one (framework-res.apk, a split) has offsets of its own
    // that can fall inside this APK's library ranges.
    if (m == null || m.group(2) != apkPath) continue;
    final offset = int.parse(m.group(1)!, radix: 16);
    for (final lib in libs) {
      if (lib.contains(offset)) found.add(lib.name.split('/').last);
    }
  }
  return found;
}

/// The libbugsee libraries on [abi] an APK carries.
Set<String> apkBugseeLibs(List<ZipEntry> apkEntries, String abi) => {
  for (final e in apkEntries)
    if (e.name.startsWith('lib/$abi/libbugsee') && e.name.endsWith('.so'))
      e.name.split('/').last,
};

/// How a process ended, from `dumpsys activity exit-info <pkg>` (the most recent record for [pid]).
class ExitInfo {
  const ExitInfo({
    required this.pid,
    required this.reason,
    required this.status,
  });
  final int pid;

  /// The text after `reason=`, e.g. `5 (APP CRASH(NATIVE))`.
  final String reason;
  final int status;

  bool get isNativeCrash => reason.startsWith('5 ');
}

ExitInfo? parseExitInfo(String dumpsys, int pid) {
  ExitInfo? best;
  for (final block in dumpsys.split(RegExp(r'ApplicationExitInfo #\d+:'))) {
    final p = RegExp(r'\bpid=(\d+)').firstMatch(block);
    if (p == null || int.parse(p.group(1)!) != pid) continue;
    final r = RegExp(r'reason=(.*)').firstMatch(block);
    final s = RegExp(r'status=(-?\d+)').firstMatch(block);
    if (r == null || s == null) continue;
    best ??= ExitInfo(
      pid: pid,
      reason: r.group(1)!.trim(),
      status: int.parse(s.group(1)!),
    );
  }
  return best;
}

/// The signal logcat says [pid] died of (`Fatal signal 11 (SIGSEGV) ... pid 5882`), or `null`.
({int number, String name, String code})? parseFatalSignal(
  String log,
  int pid,
) {
  for (final m in RegExp(
    r'Fatal signal (\d+) \((\w+)\), code (-?\d+) \(([^)]*)\)[^\n]*pid (\d+)',
  ).allMatches(log)) {
    if (int.parse(m.group(5)!) == pid) {
      return (
        number: int.parse(m.group(1)!),
        name: m.group(2)!,
        code: m.group(4)!,
      );
    }
  }
  return null;
}

/// Resolved versions of `com.bugsee:*` artefacts in a `./gradlew :app:dependencies` report
/// (`+--- com.bugsee:bugsee-android-ndk:7.4.2`, `-> 7.4.2` when resolved to another).
Map<String, Set<String>> parseGradleBugseeArtefacts(String report) {
  final out = <String, Set<String>>{};
  for (final m in RegExp(
    r'com\.bugsee:([\w-]+):(\S+)(?: -> (\S+))?',
  ).allMatches(report)) {
    out.putIfAbsent(m.group(1)!, () => {}).add(m.group(3) ?? m.group(2)!);
  }
  return out;
}

/// The version of the Bugsee Gradle plugin in a `./gradlew buildEnvironment` report.
Set<String> parseGradlePluginVersions(String report) => {
  for (final m in RegExp(
    r'com\.bugsee(?:\.android)?[.:][\w.:-]*gradle[\w.-]*:(\d+\.\d+\.\d+)(?: -> (\d+\.\d+\.\d+))?',
  ).allMatches(report))
    m.group(2) ?? m.group(1)!,
};

/// A `<provider>` of a merged manifest printed by `apkanalyzer manifest print`.
class ManifestProvider {
  const ManifestProvider(this.name, this.initOrder, this.attributes);
  final String name;
  final int? initOrder;
  final Map<String, String> attributes;
}

List<ManifestProvider> parseProviders(String manifestXml) => [
  for (final m in RegExp(
    r'<provider\b([^>]*?)/?>',
    dotAll: true,
  ).allMatches(manifestXml))
    () {
      final attrs = {
        for (final a in RegExp(r'([\w:.-]+)="([^"]*)"').allMatches(m.group(1)!))
          a.group(1)!: a.group(2)!,
      };
      return ManifestProvider(
        attrs['android:name'] ?? '',
        int.tryParse(attrs['android:initOrder'] ?? ''),
        attrs,
      );
    }(),
];

/// One `VERIFY|{json}` line the verification app printed.
class VerifyEvent {
  VerifyEvent(this.data);
  final Map<String, Object?> data;
  String get kind => data['kind'] as String;
  Object? operator [](String key) => data[key];

  @override
  String toString() => jsonEncode(data);
}

List<VerifyEvent> parseVerifyEvents(String text) => [
  for (final m in RegExp(r'VERIFY\|(\{.*\})').allMatches(text))
    ?_tryEvent(m.group(1)!),
];

VerifyEvent? _tryEvent(String json) {
  try {
    return VerifyEvent((jsonDecode(json) as Map).cast<String, Object?>());
  } on FormatException {
    return null;
  }
}

/// How the iOS simulator's launchd says a process ended: `exited due to SIGSEGV | sent by zsh[58925], ran
/// for 25033ms` for pid 58975 (the simulator's processes are host processes, so the sender is a host
/// process too).
({String signal, String sentBy})? parseIosExit(String log, int pid) {
  final m = RegExp(
    '\\[$pid\\]:\\] exited due to (\\w+) \\| sent by ([^,\\n]+)',
  ).firstMatch(log);
  return m == null ? null : (signal: m.group(1)!, sentBy: m.group(2)!.trim());
}

/// The class addresses of `otool -v -s __DATA_CONST __objc_nlclslist <binary>`: the classes that have a
/// `+load`, which the runtime calls at launch. The dump prints each 8-byte pointer as two 32-bit words,
/// and the pointers are dyld chained fixups: the low 36 bits are the target as an offset from the image
/// base ([imageBase], the executable's `__mh_execute_header`), the bits above are the fixup chain.
Set<int> parseNonLazyClassList(String otool, {int imageBase = 0x100000000}) {
  final out = <int>{};
  for (final line in otool.split('\n')) {
    final m = RegExp(
      r'^[0-9a-f]{16}\s+((?:[0-9a-f]{8}\s*)+)$',
    ).firstMatch(line.trim());
    if (m == null) continue;
    final words = m.group(1)!.trim().split(RegExp(r'\s+'));
    for (var i = 0; i + 1 < words.length; i += 2) {
      final value =
          (int.parse(words[i + 1], radix: 16) << 32) |
          int.parse(words[i], radix: 16);
      out.add(imageBase + (value & 0xFFFFFFFFF));
    }
  }
  return out;
}

/// The address of `_OBJC_CLASS_$_<name>` in `nm` output, or `null`.
int? objcClassAddress(String nm, String name) {
  final m = RegExp(
    '^([0-9a-f]{16}) [A-Za-z] _OBJC_CLASS_\\\$_$name\$',
    multiLine: true,
  ).firstMatch(nm);
  return m == null ? null : int.parse(m.group(1)!, radix: 16);
}
