// Process helpers for the harness. Every external command goes through [sh]: a timeout, captured output,
// and no global process killing (the machine is shared; the harness only ever stops what it started).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Out {
  Out(this.code, this.stdout, this.stderr, [this.bytes]);
  final int code;
  final String stdout;
  final String stderr;

  /// The raw stdout, when asked for.
  final Uint8List? bytes;

  bool get ok => code == 0;
  String get text => stdout.trim();

  @override
  String toString() => 'exit $code: ${stdout.trim()} ${stderr.trim()}';
}

Future<Out> sh(
  List<String> cmd, {
  Map<String, String>? env,
  String? cwd,
  Duration timeout = const Duration(minutes: 2),
  bool raw = false,
  String? stdin,
}) async {
  final p = await Process.start(
    cmd.first,
    cmd.sublist(1),
    environment: env,
    workingDirectory: cwd,
  );
  if (stdin != null) p.stdin.write(stdin);
  unawaited(p.stdin.close().catchError((Object _) {}));
  final outBytes = BytesBuilder(copy: false);
  final outDone = p.stdout.listen(outBytes.add).asFuture<void>();
  final err = StringBuffer();
  final errDone = p.stderr
      .transform(utf8.decoder)
      .listen(err.write)
      .asFuture<void>();
  try {
    final code = await p.exitCode.timeout(timeout);
    await Future.wait([outDone, errDone]);
    final bytes = outBytes.takeBytes();
    return Out(
      code,
      raw ? '' : utf8.decode(bytes, allowMalformed: true),
      err.toString(),
      raw ? bytes : null,
    );
  } on TimeoutException {
    p.kill(ProcessSignal.sigkill);
    return Out(124, '', 'timeout after $timeout: ${cmd.join(' ')}');
  }
}

/// Starts a long-lived child (the mock server, `flutter run`) and keeps its output.
class Child {
  Child._(this.process, this.output, this._drained);
  final Process process;
  final StringBuffer output;
  final Future<void> _drained;

  /// Completes when the child's stdout and stderr have both ended: after `process.exitCode` the last lines
  /// can still be in the pipes, so a reader of [output] that must see them (devicectl's final
  /// `App terminated due to signal N`) awaits this first. Bounded by [timeout]: a grandchild holding the
  /// pipe open must not hang the harness, the output so far is what there is.
  Future<void> drained({Duration timeout = const Duration(seconds: 10)}) =>
      _drained.timeout(timeout, onTimeout: () {});

  static Future<Child> start(
    List<String> cmd, {
    Map<String, String>? env,
    String? cwd,
  }) async {
    final p = await Process.start(
      cmd.first,
      cmd.sublist(1),
      environment: env,
      workingDirectory: cwd,
    );
    final out = StringBuffer();
    final done = () async {
      await Future.wait([
        p.stdout.transform(utf8.decoder).listen(out.write).asFuture<void>(),
        p.stderr.transform(utf8.decoder).listen(out.write).asFuture<void>(),
      ]);
    }();
    return Child._(p, out, done);
  }

  void write(String s) => process.stdin.write(s);

  Future<bool> waitFor(
    Pattern pattern, {
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (output.toString().contains(pattern)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  /// Stops this child (and only this child).
  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}

Future<void> delay(double seconds) =>
    Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));

/// Polls [check] until it returns non-null or [timeout] passes.
Future<T?> until<T>(
  Future<T?> Function() check, {
  Duration timeout = const Duration(seconds: 60),
  Duration every = const Duration(seconds: 1),
}) async {
  final end = DateTime.now().add(timeout);
  while (true) {
    final v = await check();
    if (v != null) return v;
    if (DateTime.now().isAfter(end)) return null;
    await Future<void>.delayed(every);
  }
}
