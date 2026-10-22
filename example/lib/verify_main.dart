// The app the device verification harness drives (`scripts/device/`, `doc/verification.md`).
// It is NOT the example: it launches the SDK by itself from build-time flags, registers a report
// handler that RECORDS what it saw, and takes commands from the harness over the loopback mock API,
// so the same build runs in debug, profile and release, on a device that has no debugger and no
// `run-as` (a release build is not debuggable).
//
//   flutter build apk --release -t lib/verify_main.dart \
//       --dart-define=VERIFY_SERVER=10.0.2.2:8196 --dart-define=BUGSEE_ENDPOINT=http://10.0.2.2:8196
//
// Everything it learns goes two ways: one `VERIFY|<json>` line on the console (logcat / the system
// log) and a POST to the mock API (`/__event`), whichever is reachable (airplane mode cuts the
// second). Nothing here is part of the plugin: it is built from the example app's sources.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const _server = String.fromEnvironment('VERIFY_SERVER');
const _token = String.fromEnvironment(
  'BUGSEE_TOKEN',
  defaultValue: 'EXAMPLE-APP-TOKEN',
);
const _endpoint = String.fromEnvironment('BUGSEE_ENDPOINT');

/// Changes the compiled code (a second, different build of the same source).
const _variant = String.fromEnvironment('VERIFY_VARIANT');
const _asCrash = bool.fromEnvironment('VERIFY_AS_CRASH');
const _autoLaunch = bool.fromEnvironment(
  'VERIFY_AUTOLAUNCH',
  defaultValue: true,
);

final _clock = Stopwatch()..start();

// Created BEFORE the network capture is installed: the harness's own traffic must not be a
// "request" in the report.
final HttpClient _control = HttpClient();

void _emit(String kind, [Map<String, Object?> data = const {}]) {
  final line = jsonEncode({
    'kind': kind,
    'ms': _clock.elapsedMilliseconds,
    'mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
    ...data,
  });
  // `print` is what a release build keeps on both platforms (debugPrint throttles but also prints).
  // ignore: avoid_print
  print('VERIFY|$line');
  if (_server.isNotEmpty) {
    unawaited(_post('/__event', line));
  }
}

Future<void> _post(String path, String body) async {
  try {
    final request = await _control
        .postUrl(Uri.parse('http://$_server$path'))
        .timeout(const Duration(seconds: 2));
    final bytes = utf8.encode(body);
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(const Duration(seconds: 2));
    await response.drain<void>();
  } on Object {
    // Offline (airplane mode) or the server is gone: the console line is the record.
  }
}

Future<String?> _nextCommand() async {
  try {
    final request = await _control
        .getUrl(Uri.parse('http://$_server/__cmd'))
        .timeout(const Duration(seconds: 2));
    final response = await request.close().timeout(const Duration(seconds: 2));
    final body = await utf8.decodeStream(response);
    if (response.statusCode != 200 || body.isEmpty) return null;
    return body;
  } on Object {
    return null;
  }
}

BugseeOptions _options() => BugseeOptions(
  endpoint: _endpoint.isEmpty ? null : _endpoint,
  captureVideo: true,
  captureNetwork: true,
  captureLogs: true,
  captureLogsLevel: LogLevel.info,
  captureBreadcrumbs: true,
  detectHang: false,
  configWifiOnlyUpload: false,
  reportingDefaultsCrashPriority: ReportSeverity.critical,
);

/// What the handler saw, for the harness: written into the report itself (an attribute and an
/// attached file, which is exactly the "enrichment lands in the recovered bundle" question) and
/// emitted.
Future<void> _record(String phase, ReportProxy report) async {
  final seen = <String, Object?>{
    'phase': phase,
    'type': report.typeName,
    'deliveryId': report.deliveryId,
    'handlerMs': _clock.elapsedMilliseconds,
    'isolate': Isolate.current.debugName,
  };
  _emit('handler', seen);
  try {
    await report.setAttribute('verify.$phase', jsonEncode(seen));
    if (phase == 'before') {
      final dir = await Directory.systemTemp.createTemp('verify-attach');
      final file = File('${dir.path}/verify-enrichment.txt')
        ..writeAsStringSync('enrichment from the Dart handler: $phase');
      await report.addAttachment(
        file.path,
        name: 'verify-enrichment',
        mimeType: 'text/plain',
        move: true,
      );
    } else {
      await report.addLabels(['verify-after']);
    }
  } on Object catch (e) {
    _emit('handler-error', {'phase': phase, 'error': e.toString()});
  }
}

const _handler = BugseeReportHandler(
  onBeforeReportCreated: _before,
  onAfterReportCreated: _after,
);
File? _pendingFile;

Future<void> _before(ReportProxy r) async {
  await _record('before', r);
  final file = _pendingFile;
  if (file != null) {
    _pendingFile = null;
    await r.addAttachment(
      file.path,
      name: 'from-command',
      mimeType: 'text/plain',
    );
  }
}

Future<void> _after(ReportProxy r) => _record('after', r);

final _secureKey = GlobalKey();
bool _secureOn = true;
final _secureNotifier = ValueNotifier<bool>(true);

Future<void> _command(String command) async {
  final parts = command.split(' ');
  final name = parts.first;
  final arg = parts.length > 1 ? parts.sublist(1).join(' ') : '';
  _emit('command', {'name': name, 'arg': arg});
  try {
    switch (name) {
      case 'status':
        _emit('status', {'status': (await Bugsee.getStatus()).name});
      case 'launch':
        final r = await Bugsee.launch(_token, options: _options());
        _emit('launch', {'result': r.name});
      case 'log-handled':
        try {
          throw FormatException('verify handled $arg');
        } catch (e, s) {
          await Bugsee.logException(e, s);
        }
      case 'log-unhandled':
        await Bugsee.logUnhandledException(StateError('verify unhandled $arg'));
      case 'throw-async':
        // Nobody awaits it: it reaches the installed error handlers.
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 10),
          ).then((_) => throw StateError('verify async $arg')),
        );
      case 'upload':
        await Bugsee.upload(
          'verify upload $arg',
          'sent by the verification driver',
        );
      case 'upload-with-file':
        // Attached from the report handler (the public way): the handler picks the file up when the SDK
        // asks for it, which is after `upload` returns.
        final dir = await Directory.systemTemp.createTemp('verify-file');
        _pendingFile = File('${dir.path}/from-command.txt')
          ..writeAsStringSync('attached by a command $arg');
        await Bugsee.upload('verify upload-with-file $arg', 'with a file');
      case 'create-report':
        final report = await Bugsee.createReport();
        if (report == null) {
          _emit('create-report', {'result': 'none'});
        } else {
          await report.setSummary('verify created $arg');
          await report.upload();
          _emit('create-report', {'result': 'uploaded'});
        }
      case 'vh':
        await Bugsee.captureViewHierarchy();
      case 'net':
        // `arg` is the full URL. It must NOT be the Bugsee endpoint's host: that traffic is never
        // captured (by design), so a request to it could not show that capture works.
        final c = HttpClient();
        final request = await c.getUrl(Uri.parse(arg));
        final response = await request.close();
        await response.drain<void>();
        c.close();
      case 'print':
        // ignore: avoid_print
        print('verify-log-marker $arg');
        debugPrint('verify-debugprint-marker $arg');
      case 'secure':
        _secureOn = arg != 'off';
        _secureNotifier.value = _secureOn;
      case 'geometry':
        _emitGeometry();
      case 'stop':
        await Bugsee.stop();
      default:
        _emit('unknown-command', {'name': name});
    }
  } on Object catch (e, s) {
    _emit('command-error', {
      'name': name,
      'error': e.toString(),
      'stack': s.toString(),
    });
  }
}

void _emitGeometry() {
  final view = ui.PlatformDispatcher.instance.views.first;
  final box = _secureKey.currentContext?.findRenderObject() as RenderBox?;
  Map<String, Object?>? rect;
  if (box != null && box.attached) {
    final o = box.localToGlobal(Offset.zero);
    rect = {'x': o.dx, 'y': o.dy, 'w': box.size.width, 'h': box.size.height};
  }
  _emit('geometry', {
    'devicePixelRatio': view.devicePixelRatio,
    'physicalWidth': view.physicalSize.width,
    'physicalHeight': view.physicalSize.height,
    'secureLogical': rect,
    'secureOn': _secureOn,
  });
}

Future<void> _poll() async {
  while (true) {
    final command = await _nextCommand();
    if (command != null) {
      await _command(command);
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
}

void main() {
  Bugsee.runGuarded(() async {
    // First, before anything else can print: everything that follows belongs to this isolate (a hot
    // restart starts a new one in the same process, and the harness splits the log at this line).
    _emit('main', {
      'pid': pid,
      'wrapperVersion': bugseeFlutterVersion,
      'dart': Platform.version.split(' ').first,
      'os': Platform.operatingSystem,
      'variant': _variant,
    });
    WidgetsFlutterBinding.ensureInitialized();
    Bugsee.installLogCapture();
    Bugsee.installNetworkCapture();
    Bugsee.installErrorHandlers(reportAsCrash: _asCrash);
    await Bugsee.setReportHandler(_handler);
    Bugsee.statusChanges.listen(
      (s) => _emit('status-change', {'status': s.name}),
    );
    Bugsee.lifecycleEvents.listen(
      (e) => _emit('lifecycle', {'event': e.toString()}),
    );
    // What this isolate's synchronous `Bugsee.status` says once the plugin has had a moment to attach
    // (after a hot restart the SDK is already launched: is the new isolate told?).
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 2),
        () => _emit('status-sync', {'status': Bugsee.status.name}),
      ),
    );
    runApp(const _VerifyApp());
    if (_autoLaunch) {
      try {
        final r = await Bugsee.launch(_token, options: _options());
        _emit('launch', {'result': r.name});
        _emit('status', {'status': (await Bugsee.getStatus()).name});
      } on Object catch (e) {
        _emit('launch-error', {'error': e.toString()});
      }
    }
    if (_server.isNotEmpty) unawaited(_poll());
    SchedulerBinding.instance.addPostFrameCallback((_) => _emitGeometry());
  });
}

class _VerifyApp extends StatelessWidget {
  const _VerifyApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Bugsee verify',
    home: Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Bugsee verification driver'),
            ),
            // A solid, saturated block: a pixel check can tell it from its redaction.
            Padding(
              padding: const EdgeInsets.all(24),
              child: ValueListenableBuilder<bool>(
                valueListenable: _secureNotifier,
                builder: (_, on, _) => BugseeSecureView(
                  enabled: on,
                  child: SizedBox(
                    key: _secureKey,
                    width: 240,
                    height: 120,
                    child: const ColoredBox(color: Color(0xFFFF00FF)),
                  ),
                ),
              ),
            ),
            Container(width: 240, height: 60, color: const Color(0xFF00C000)),
          ],
        ),
      ),
    ),
  );
}
