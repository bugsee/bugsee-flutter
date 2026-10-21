import 'dart:async';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/material.dart';

/// The rest of the API in one place: attributes and identity, events and traces, logs and
/// breadcrumbs, notifications, blackout, secure views, reports and the lifecycle events. Every
/// button is one call; the result (or the typed error) goes into the log below.
class FacadeScreen extends StatefulWidget {
  const FacadeScreen({super.key});

  @override
  State<FacadeScreen> createState() => _FacadeScreenState();
}

class _FacadeScreenState extends State<FacadeScreen> {
  final _log = <String>[];
  late final StreamSubscription<LifecycleEvent> _events;
  bool _blackout = false;
  bool _secure = true;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    // Every SDK lifecycle event, names this version does not know included.
    _events = Bugsee.lifecycleEvents.listen(
      (e) => _note(
        'lifecycle: ${e.name}${e.reportId == null ? '' : ' (${e.reportId})'}',
      ),
    );
  }

  @override
  void dispose() {
    _events.cancel();
    super.dispose();
  }

  void _note(String line) {
    debugPrint('example: $line');
    if (mounted) setState(() => _log.insert(0, line));
  }

  Future<void> _run(String name, Future<Object?> Function() action) async {
    try {
      final result = await action();
      _note(result == null ? name : '$name -> $result');
    } on BugseeAttributeException catch (e) {
      _note('$name failed: ${e.reason.name} (${e.message})');
    } on BugseeArgumentException catch (e) {
      _note('$name failed: bad ${e.argument} (${e.message})');
    } on BugseeException catch (e) {
      _note('$name failed: ${e.message}');
    }
  }

  Widget _button(String label, Future<Object?> Function() action) =>
      OutlinedButton(
        key: Key(label),
        onPressed: () => _run(label, action),
        child: Text(label),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Bugsee data')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _button('set attribute', () async {
                  await Bugsee.setAttribute('plan', 'pro');
                  await Bugsee.setAttribute('seats', 5);
                  await Bugsee.setAttribute('beta', true);
                  return Bugsee.getAllAttributes();
                }),
                _button('clear attributes', Bugsee.clearAllAttributes),
                _button('set user', () async {
                  await Bugsee.setUserIdentifier('user@example.com');
                  return Bugsee.getUserIdentifier();
                }),
                _button('clear user', Bugsee.clearUserIdentifier),
                _button(
                  'event',
                  () => Bugsee.event('opened', {'screen': 'data'}),
                ),
                _button('trace', () => Bugsee.trace('taps', ++_count)),
                _button(
                  'log',
                  () => Bugsee.log('hello', level: LogLevel.warning),
                ),
                _button(
                  'breadcrumb',
                  () => Bugsee.addBreadcrumb(
                    const BugseeBreadcrumb(
                      category: 'ui',
                      message: 'tapped breadcrumb',
                      type: 'user',
                      data: {'screen': 'data'},
                    ),
                  ),
                ),
                _button(
                  'notify',
                  () => Bugsee.notify(
                    'Example',
                    body: 'from the example app',
                    severity: ReportSeverity.medium,
                    fields: {'where': 'example'},
                  ),
                ),
                _button(
                  'upload report',
                  () => Bugsee.upload(
                    'Example report',
                    'Sent from the example app',
                    severity: ReportSeverity.high,
                  ),
                ),
                _button(
                  'report dialog',
                  () => Bugsee.showReportDialog(summary: 'Example'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const Key('blackout'),
              title: const Text('Blackout (video, screenshot, touches)'),
              value: _blackout,
              onChanged: (on) =>
                  _run('blackout ${on ? 'on' : 'off'}', () async {
                    await (on ? Bugsee.startBlackout() : Bugsee.endBlackout());
                    final state = await Bugsee.isBlackout();
                    if (mounted) setState(() => _blackout = state);
                    return state;
                  }),
            ),
            SwitchListTile(
              key: const Key('secure'),
              title: const Text('Hide the card field from the recording'),
              value: _secure,
              onChanged: (on) => setState(() => _secure = on),
            ),
            BugseeSecureView(
              enabled: _secure,
              child: const TextField(
                key: Key('card'),
                decoration: InputDecoration(
                  labelText: 'Card number (secure)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const Divider(height: 24),
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
