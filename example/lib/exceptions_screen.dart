import 'dart:async';
import 'dart:isolate';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/material.dart';

/// Dart errors: reporting one yourself (`Bugsee.logException`), and the opt-in capture of the
/// ones nobody handled (`Bugsee.installErrorHandlers`). Each button throws or reports one error;
/// the log shows what the SDK was handed. Reports need a launched SDK (the Launch tab) and a real
/// token to leave the device.
class ExceptionsScreen extends StatefulWidget {
  const ExceptionsScreen({super.key});

  @override
  State<ExceptionsScreen> createState() => _ExceptionsScreenState();
}

/// The entry point of a spawned isolate: throws, uncaught.
void _isolateThatThrows(Object? _) =>
    throw StateError('uncaught in a spawned isolate');

class _ExceptionsScreenState extends State<ExceptionsScreen> {
  final _log = <String>[];
  bool _installed = false;
  bool _asCrash = true;

  void _note(String line) {
    debugPrint('example: $line');
    if (mounted) setState(() => _log.insert(0, line));
  }

  Future<void> _run(String name, Future<Object?> Function() action) async {
    try {
      _note('$name -> ${await action()}');
    } on BugseeException catch (e) {
      _note('$name failed: ${e.message}');
    }
  }

  void _toggleInstall() {
    if (_installed) {
      Bugsee.uninstallErrorHandlers();
    } else {
      // Chained to the handlers already there: the console still prints every error.
      Bugsee.installErrorHandlers(reportAsCrash: _asCrash);
    }
    setState(() => _installed = Bugsee.errorHandlersInstalled);
    _note('error handlers installed: $_installed');
  }

  Widget _button(String label, VoidCallback onPressed) =>
      OutlinedButton(key: Key(label), onPressed: onPressed, child: Text(label));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Dart errors')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const Key('as-crash'),
              title: const Text('Report unhandled as crash'),
              subtitle: const Text(
                'Off: as error reports. Applies to the next install.',
              ),
              value: _asCrash,
              onChanged: _installed
                  ? null
                  : (v) => setState(() => _asCrash = v),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const Key('install'),
                  onPressed: _toggleInstall,
                  child: Text(
                    _installed ? 'Uninstall handlers' : 'Install handlers',
                  ),
                ),
                _button('log handled', () {
                  try {
                    throw FormatException('handled in the example');
                  } catch (e, s) {
                    _run('logException', () => Bugsee.logException(e, s));
                  }
                }),
                _button('log unhandled', () {
                  _run(
                    'logException(handled: false)',
                    () => Bugsee.logException(
                      StateError('reported as unhandled'),
                      null,
                      handled: false,
                      domain: 'example',
                    ),
                  );
                }),
                _button('FlutterError', () {
                  FlutterError.reportError(
                    FlutterErrorDetails(
                      exception: StateError('a framework-reported error'),
                      stack: StackTrace.current,
                      library: 'example',
                    ),
                  );
                }),
                _button('async error', () {
                  // Nobody awaits it: it reaches PlatformDispatcher.onError.
                  unawaited(
                    Future<void>.delayed(
                      const Duration(milliseconds: 10),
                    ).then((_) => throw StateError('an uncaught async error')),
                  );
                }),
                _button('thrown string', () {
                  unawaited(
                    Future<void>.delayed(
                      const Duration(milliseconds: 10),
                    ).then((_) => throw 'a thrown string'),
                  );
                }),
                _button('guarded zone', () {
                  Bugsee.runGuarded(() {
                    Timer.run(
                      () => throw StateError('a timer error in a guarded zone'),
                    );
                  }, onError: (e, s) => _note('zone handler got: $e'));
                }),
                _button('isolate error', () async {
                  final isolate = await Isolate.spawn(
                    _isolateThatThrows,
                    null,
                    paused: true,
                    errorsAreFatal: false,
                  );
                  final listener = Bugsee.listenToIsolateErrors(isolate);
                  isolate.resume(isolate.pauseCapability!);
                  await Future<void>.delayed(const Duration(seconds: 1));
                  listener.cancel();
                  isolate.kill(priority: Isolate.immediate);
                  _note('isolate listener done');
                }),
                _button('repeat x100', () {
                  for (var i = 0; i < 100; i++) {
                    FlutterError.reportError(
                      FlutterErrorDetails(
                        exception: FlutterError('the same error, again'),
                      ),
                    );
                  }
                  _note(
                    'reported the same error 100 times: the limiter lets one through',
                  );
                }),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(children: [for (final line in _log) Text(line)]),
            ),
          ],
        ),
      ),
    ),
  );
}
