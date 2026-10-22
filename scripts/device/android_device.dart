// One Android emulator, driven with adb. Every call names the serial (`-s`): other agents and a
// physical phone share this host, and the harness never touches a device it was not given.
import 'dart:typed_data';

import 'core/log_parsers.dart';
import 'shell.dart';
import 'toolchain.dart';

class AndroidDevice {
  AndroidDevice(this.tc, this.serial, this.pkg);
  final Toolchain tc;
  final String serial;
  final String pkg;

  bool _root = false;
  bool get hasRoot => _root;

  /// Use `run-as` (the workbook 9.3 recipe) instead of the root shell. Set per installed build: a
  /// debuggable build is reached with `run-as`, a release build (not debuggable) only with root.
  bool useRunAs = false;
  bool get _direct => _root && !useRunAs;

  /// adb, with the retries an adb server restart (another agent's `adb kill-server`) needs.
  Future<Out> adb(
    List<String> args, {
    bool raw = false,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    Out? last;
    for (var attempt = 0; attempt < 4; attempt++) {
      last = await sh(
        [tc.adbPath, '-s', serial, ...args],
        raw: raw,
        timeout: timeout,
      );
      final bad =
          last.stderr.contains('not found') ||
          last.stderr.contains('device offline') ||
          last.stderr.contains('daemon not running') ||
          last.stderr.contains('cannot connect to daemon');
      if (!bad) return last;
      await sh([tc.adbPath, 'start-server']);
      await sh([
        tc.adbPath,
        '-s',
        serial,
        'wait-for-device',
      ], timeout: const Duration(seconds: 60));
    }
    return last!;
  }

  Future<String> shell(
    String command, {
    Duration timeout = const Duration(minutes: 2),
  }) async => (await adb(['shell', command], timeout: timeout)).stdout;

  Future<String> prop(String name) async =>
      (await shell('getprop $name')).trim();

  Future<bool> isBooted() async => await prop('sys.boot_completed') == '1';

  /// `adb root` (an emulator image with Google APIs, not Play Store, allows it). Returns whether the
  /// shell is root afterwards.
  Future<bool> enableRoot() async {
    await adb(['root']);
    await sh([tc.adbPath, '-s', serial, 'wait-for-device']);
    await delay(1);
    _root = (await shell('id')).contains('uid=0');
    return _root;
  }

  Future<Out> install(String apk) =>
      adb(['install', '-r', apk], timeout: const Duration(minutes: 4));

  Future<void> uninstall() async => adb(['uninstall', pkg]);

  Future<bool> isInstalled() async =>
      (await shell('pm list packages $pkg')).contains('package:$pkg');

  Future<void> forceStop() async => adb(['shell', 'am', 'force-stop', pkg]);

  /// Starts the launcher activity.
  Future<void> start() async {
    await adb(['shell', 'am', 'start', '-n', '$pkg/.MainActivity']);
  }

  Future<int?> pid() async {
    final out = (await shell('pidof $pkg')).trim();
    return int.tryParse(out.split(' ').first);
  }

  Future<int?> waitForPid({
    Duration timeout = const Duration(seconds: 30),
    int? not,
  }) => until<int>(() async {
    final p = await pid();
    return p != null && p != not ? p : null;
  }, timeout: timeout).then((v) => v);

  Future<void> clearLogcat() async {
    for (var i = 0; i < 3; i++) {
      final r = await adb(['logcat', '-b', 'all', '-c']);
      if (r.ok && !r.stderr.contains('failed')) return;
      await delay(1);
    }
  }

  /// The whole log buffer, with the wall-clock and process ids.
  Future<String> logcat() async => (await adb([
    'logcat',
    '-d',
    '-b',
    'main,system,crash',
    '-v',
    'threadtime',
  ], timeout: const Duration(minutes: 2))).stdout;

  Future<List<VerifyEvent>> events() async => parseVerifyEvents(await logcat());

  /// `run-as` works for a debuggable build; otherwise the root shell reads the app's directory.
  Future<bool> isDebuggable() async =>
      (await adb(['shell', 'run-as', pkg, 'true'])).ok;

  String get dataDir => '/data/data/$pkg';

  /// A command inside the app's data directory: as root when the shell is root (any build), through
  /// `run-as` otherwise (debuggable builds only). Returns the access method in [via].
  String get via => _direct ? 'adb root' : 'run-as';

  Future<Out> inApp(List<String> command, {bool raw = false}) {
    if (_direct) return adb(['shell', command.join(' ')], raw: raw);
    return adb(['shell', 'run-as', pkg, ...command], raw: raw);
  }

  Future<List<String>> listBundles() async {
    final dir = _direct
        ? '$dataDir/files/bugsee_data/bundles'
        : 'files/bugsee_data/bundles';
    final out = await inApp(['ls', dir]);
    return [
      for (final l in out.stdout.split('\n'))
        if (l.trim().endsWith('.bundle.zip')) l.trim(),
    ];
  }

  Future<Uint8List> readBundle(String name) async {
    final dir = _direct
        ? '$dataDir/files/bugsee_data/bundles'
        : 'files/bugsee_data/bundles';
    final out = await adb(
      _direct
          ? ['exec-out', 'cat', '$dir/$name']
          : ['exec-out', 'run-as', pkg, 'cat', '$dir/$name'],
      raw: true,
    );
    return out.bytes!;
  }

  /// Deletes the app's retained bundles; returns what is left.
  Future<List<String>> clearBundles() async {
    final dir = _direct
        ? '$dataDir/files/bugsee_data/bundles'
        : 'files/bugsee_data/bundles';
    await inApp(['sh', '-c', "'rm -f $dir/*'"]);
    return listBundles();
  }

  Future<String> maps(int pid) async =>
      (await inApp(['cat', '/proc/$pid/maps'])).stdout;

  /// SIGSEGV to the app process (workbook 9.3.1: `run-as <pkg> kill -11`; a plain `adb shell kill` is
  /// not permitted for an app process; a root shell may, which is how a non-debuggable release build
  /// is crashed).
  Future<Out> killSegv(int pid) => inApp(['kill', '-11', '$pid']);

  Future<String> exitInfo() async => shell('dumpsys activity exit-info $pkg');

  Future<void> airplane(bool on) async {
    await adb([
      'shell',
      'cmd',
      'connectivity',
      'airplane-mode',
      on ? 'enable' : 'disable',
    ]);
    await delay(3);
  }

  Future<bool> airplaneOn() async =>
      (await shell('settings get global airplane_mode_on')).trim() == '1';

  Future<void> density(int? dpi) async {
    await adb(['shell', 'wm', 'density', dpi == null ? 'reset' : '$dpi']);
    await delay(3);
  }

  Future<int> currentDensity() async {
    final out = await shell('wm density');
    final override = RegExp(r'Override density: (\d+)').firstMatch(out);
    final physical = RegExp(r'Physical density: (\d+)').firstMatch(out);
    return int.parse((override ?? physical)!.group(1)!);
  }

  /// `adb reverse`: the device's 127.0.0.1:port reaches the host's mock API too, a second name for the
  /// same server (the Bugsee endpoint's host is never captured, so network capture needs another one).
  Future<bool> reverse(int port) async {
    await adb(['reverse', 'tcp:$port', 'tcp:$port']);
    return (await adb(['reverse', '--list'])).stdout.contains('tcp:$port');
  }

  Future<void> unreverse(int port) async =>
      adb(['reverse', '--remove', 'tcp:$port']);

  Future<Uint8List> screencap() async =>
      (await adb(['exec-out', 'screencap', '-p'], raw: true)).bytes!;

  /// The package's version code and name as the package manager has them.
  Future<({String? code, String? name})> packageVersion() async {
    final out = await shell('dumpsys package $pkg');
    return (
      code: RegExp(r'versionCode=(\d+)').firstMatch(out)?.group(1),
      name: RegExp(r'versionName=(\S+)').firstMatch(out)?.group(1),
    );
  }

  Future<String> abi() async => (await prop('ro.product.cpu.abi'));
}
