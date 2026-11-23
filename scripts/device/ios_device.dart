// One iOS simulator, driven with simctl. The harness only touches the simulator it is given (by UDID);
// it never uses `booted` and never stops anything it did not start.
import 'dart:io';

import 'core/log_parsers.dart';
import 'shell.dart';

class IosDevice {
  IosDevice(this.udid, this.bundleId);
  final String udid;
  final String bundleId;

  Future<Out> _simctl(
    List<String> args, {
    Duration timeout = const Duration(minutes: 2),
    bool raw = false,
  }) => sh(['xcrun', 'simctl', ...args], timeout: timeout, raw: raw);

  Future<Out> simctl(
    List<String> args, {
    Duration timeout = const Duration(minutes: 2),
  }) => _simctl(args, timeout: timeout);

  Future<bool> isBooted() async {
    final out = await _simctl(['list', 'devices']);
    return RegExp('$udid\\)\\s+\\(Booted\\)').hasMatch(out.stdout);
  }

  Future<String> runtime() async {
    final out = await _simctl(['list', 'devices']);
    final lines = out.stdout.split('\n');
    var current = '';
    for (final l in lines) {
      if (l.startsWith('-- ')) current = l.replaceAll('-', '').trim();
      if (l.contains(udid)) return current;
    }
    return 'unknown';
  }

  Future<String> deviceName() async {
    final out = await _simctl(['list', 'devices']);
    final m = RegExp(
      '^\\s+(.+?) \\($udid\\)',
      multiLine: true,
    ).firstMatch(out.stdout);
    return m?.group(1) ?? 'unknown';
  }

  Future<Out> install(String app) =>
      _simctl(['install', udid, app], timeout: const Duration(minutes: 4));

  Future<void> uninstall() async => _simctl(['uninstall', udid, bundleId]);

  Future<bool> isInstalled() async =>
      (await _simctl(['get_app_container', udid, bundleId])).ok;

  Future<void> terminate() async => _simctl(['terminate', udid, bundleId]);

  /// Launches the app and returns its pid.
  Future<int?> launch({
    List<String> args = const [],
    Map<String, String> env = const {},
  }) async {
    final out = await sh(
      ['xcrun', 'simctl', 'launch', udid, bundleId, ...args],
      env: {
        ...Platform.environment,
        for (final e in env.entries) 'SIMCTL_CHILD_${e.key}': e.value,
      },
    );
    return int.tryParse(
      RegExp(r':\s*(\d+)\s*$').firstMatch(out.stdout.trim())?.group(1) ?? '',
    );
  }

  /// Whether [pid] is alive (the simulator's processes are host processes).
  bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  /// SIGSEGV to the app (a simulator process is a host process: no run-as needed).
  Future<Out> killSegv(int pid) => sh(['kill', '-SEGV', '$pid']);

  Future<String?> dataContainer() async {
    final out = await _simctl(['get_app_container', udid, bundleId, 'data']);
    return out.ok ? out.text : null;
  }

  /// The simulator's unified log for the app since [since] (host local time).
  Future<String> log({required DateTime since}) async {
    final start = since.subtract(const Duration(seconds: 2));
    String two(int n) => n.toString().padLeft(2, '0');
    final ts =
        '${start.year}-${two(start.month)}-${two(start.day)} ${two(start.hour)}:${two(start.minute)}:${two(start.second)}';
    final out = await _simctl([
      'spawn',
      udid,
      'log',
      'show',
      '--style',
      'compact',
      '--info',
      '--debug',
      '--start',
      ts,
      '--predicate',
      'process == "Runner"',
    ], timeout: const Duration(minutes: 3));
    return out.stdout;
  }

  Future<List<VerifyEvent>> events({required DateTime since}) async =>
      parseVerifyEvents(await log(since: since));

  /// The device screen as PNG bytes.
  Future<Out> screenshot(String path) =>
      _simctl(['io', udid, 'screenshot', path]);

  Future<void> boot() async {
    await _simctl(['boot', udid]);
    await _simctl(['bootstatus', udid], timeout: const Duration(minutes: 5));
  }
}
