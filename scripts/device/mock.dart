// The loopback mock API (example/integration_test/support/mock_api.py) the apps talk to: it carries the
// harness's commands to the verification app and the app's events back, and stores every bundle an SDK
// uploads. It binds 127.0.0.1 only; the Android emulator reaches it as 10.0.2.2, the iOS simulator as
// localhost.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'shell.dart';

class Mock {
  Mock._(this.port, this.child, this.dumpDir, this.logFile);
  final int port;
  final Child child;
  final String dumpDir;
  final String logFile;

  static Future<Mock> start(
    String repoRoot,
    String workDir,
    int port, {
    int uploadStatus = 503,
  }) async {
    // One directory and one log per port: the platforms run side by side.
    // The port must be free: a stray server on it (a manual run, another harness) would answer the
    // readiness probe and the harness would talk to the wrong one.
    try {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await probe.close();
    } on SocketException {
      throw StateError(
        '127.0.0.1:$port is already in use: stop whatever listens there, or pass --port',
      );
    }
    // iOS bundles are zstd zips (method 93), which Python's zipfile reads from 3.14 on: with an older
    // python3 every iOS scenario would end INVALID with "no bundle reached the mock".
    final py = await sh([
      'python3',
      '-c',
      'import sys; print(sys.version_info[0] * 100 + sys.version_info[1])',
    ]);
    if (!py.ok || (int.tryParse(py.text) ?? 0) < 314) {
      throw StateError(
        'python3 3.14 or later is required (the mock reads zstd zip entries): found ${py.ok ? py.text : py.stderr}',
      );
    }
    final dump = '$workDir/mock-bundles-$port';
    Directory(dump).createSync(recursive: true);
    final log = '$workDir/mock-$port.log';
    final child = await Child.start(
      [
        'python3',
        '-I',
        '$repoRoot/example/integration_test/support/mock_api.py',
        '$port',
        log,
      ],
      env: {
        ...Platform.environment,
        'ISSUE_OK': '1',
        'UPLOAD_STATUS': '$uploadStatus',
        'DUMP_DIR': dump,
      },
    );
    final mock = Mock._(port, child, dump, log);
    final up = await until(
      () async => await mock._get('/__events') != null ? true : null,
      timeout: const Duration(seconds: 15),
      every: const Duration(milliseconds: 300),
    );
    if (up == null) {
      await child.stop();
      throw StateError(
        'the mock API did not start on 127.0.0.1:$port: ${child.output}',
      );
    }
    return mock;
  }

  Future<String?> _get(String path) async {
    final c = HttpClient();
    try {
      final r = await (await c.getUrl(
        Uri.parse('http://127.0.0.1:$port$path'),
      )).close();
      return await utf8.decodeStream(r);
    } on Object {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _post(String path, [String body = '']) async {
    final c = HttpClient();
    try {
      final r = await c.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
      final bytes = utf8.encode(body);
      r.contentLength = bytes.length;
      r.add(bytes);
      await (await r.close()).drain<void>();
    } finally {
      c.close(force: true);
    }
  }

  /// Queues one command for the verification app.
  Future<void> command(String line) => _post('/__cmd', line);

  Future<void> reset() => _post('/__reset');

  Future<void> mode({int? upload}) =>
      _post('/__mode?${upload == null ? '' : 'upload=$upload'}');

  /// The events the app reported (each a JSON object).
  Future<List<Map<String, Object?>>> events() async {
    final body = await _get('/__events');
    if (body == null) return const [];
    return [
      for (final e in jsonDecode(body) as List)
        if (e is Map) e.cast<String, Object?>(),
    ];
  }

  /// The bundles the server stored (decoded manifest/request, entries with sizes and hashes).
  Future<List<Map<String, Object?>>> bundles() async {
    final body = await _get('/__bundles');
    if (body == null) return const [];
    return [
      for (final b in jsonDecode(body) as List)
        (b as Map).cast<String, Object?>(),
    ];
  }

  /// The names of the files the server stored.
  List<String> storedNames() => [
    for (final f in Directory(dumpDir).listSync())
      if (f is File && f.path.endsWith('.zip')) f.uri.pathSegments.last,
  ];

  /// A stored bundle as a zip `dart:io` can read: the server re-writes it with deflate (iOS compresses
  /// its bundles with zstd, zip method 93).
  Future<Uint8List?> plainBundle(String name) async {
    final c = HttpClient();
    try {
      final r = await (await c.getUrl(
        Uri.parse(
          'http://127.0.0.1:$port/__plain?file=${Uri.encodeQueryComponent(name)}',
        ),
      )).close();
      if (r.statusCode != 200) return null;
      final b = BytesBuilder();
      await for (final chunk in r) {
        b.add(chunk);
      }
      return b.takeBytes();
    } on Object {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  Future<void> stop() => child.stop();
}
