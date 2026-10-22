// ignore_for_file: avoid_print
import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/material.dart';

/// Log capture (`Bugsee.installLogCapture`, called in `main`): what the app prints from Dart is
/// recorded into the report with the plugin's own source, apart from the deliberate `Bugsee.log`
/// calls. Each button prints one kind of line; the filter switch turns on a Dart-side filter that
/// masks digits and drops lines mentioning `internal` BEFORE anything reaches the SDK.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final _text = TextEditingController(text: 'card 4111111111111111');
  final _log = <String>[];
  bool _filter = false;
  LogLevel _level = LogLevel.info;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _note(String line) {
    if (mounted) setState(() => _log.insert(0, line));
  }

  void _setFilter(bool on) {
    setState(() => _filter = on);
    if (!on) {
      Bugsee.setLogFilter(null);
      return;
    }
    // Runs in Dart, before the line reaches the SDK: it cannot be bypassed. Returning `null`
    // drops the line; a filter that throws or hangs drops it too. The SDK has no log sanitizer of
    // its own, so this is where redaction belongs.
    Bugsee.setLogFilter((event) {
      if (event.message.contains('internal')) return null;
      event.message = event.message.replaceAll(RegExp(r'\d{4,}'), '<digits>');
      return event;
    });
  }

  Widget _button(String label, VoidCallback onPressed) =>
      OutlinedButton(key: Key(label), onPressed: onPressed, child: Text(label));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Log capture')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _text,
              decoration: const InputDecoration(
                labelText: 'Line',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _button('print', () {
                  print(_text.text);
                  _note('print');
                }),
                _button('debugPrint', () {
                  debugPrint(_text.text);
                  _note('debugPrint');
                }),
                _button('forwardLog', () {
                  final taken = Bugsee.forwardLog(
                    _text.text,
                    level: _level,
                    tag: 'example',
                  );
                  _note('forwardLog(${_level.name}) -> $taken');
                }),
                _button('Bugsee.log', () async {
                  await Bugsee.log(_text.text, level: _level);
                  _note(
                    'Bugsee.log(${_level.name}) (the app\'s own, not captured)',
                  );
                }),
                _button('flood', () {
                  for (var i = 0; i < 2000; i++) {
                    print('flood line $i');
                  }
                  _note('2000 lines printed');
                }),
                _button('Stats', () => _note('${Bugsee.logCaptureStats}')),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButton<LogLevel>(
              key: const Key('level'),
              value: _level,
              items: [
                for (final l in LogLevel.values)
                  DropdownMenuItem(value: l, child: Text(l.name)),
              ],
              onChanged: (l) => setState(() => _level = l ?? _level),
            ),
            SwitchListTile(
              key: const Key('filter'),
              title: const Text('Dart filter (mask digits, drop "internal")'),
              value: _filter,
              onChanged: _setFilter,
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) =>
                    Text(_log[i], style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
