import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/material.dart';

/// Network capture (`Bugsee.installNetworkCapture`, called in `main`): ordinary `dart:io` requests
/// the SDK cannot see by itself, recorded into the report with the SDK's own privacy rules. Each
/// button makes one request; the filter switch turns on a Dart-side filter that hides one header
/// and drops one URL BEFORE anything reaches the SDK.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  final _url = TextEditingController(text: 'https://httpbin.org');
  final _log = <String>[];
  bool _filter = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _note(String line) {
    debugPrint('example: $line');
    if (mounted) setState(() => _log.insert(0, line));
  }

  Future<void> _request(
    String name,
    String method,
    String path, {
    Object? json,
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    final started = DateTime.now();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('${_url.text}$path'),
      );
      headers.forEach(request.headers.set);
      if (json != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(json));
      }
      final response = await request.close();
      final bytes = await response.fold<int>(0, (n, chunk) => n + chunk.length);
      _note(
        '$name -> ${response.statusCode}, $bytes bytes, '
        '${DateTime.now().difference(started).inMilliseconds} ms',
      );
    } on Object catch (e) {
      _note('$name failed: ${e.runtimeType}');
    } finally {
      client.close();
    }
  }

  void _setFilter(bool on) {
    setState(() => _filter = on);
    if (!on) {
      Bugsee.setNetworkFilter(null);
      return;
    }
    // Runs in Dart, before the event reaches the SDK: it cannot be bypassed. Returning `null`
    // drops the event; a filter that throws or hangs drops it too.
    Bugsee.setNetworkFilter((event) {
      if (event.url.contains('/secret')) return null;
      event.headers.remove('x-session');
      return event;
    });
  }

  Widget _button(String label, VoidCallback onPressed) =>
      OutlinedButton(key: Key(label), onPressed: onPressed, child: Text(label));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Network capture')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Server',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _button('GET', () => _request('GET', 'GET', '/get?q=bugsee')),
                _button(
                  'POST JSON',
                  () => _request(
                    'POST',
                    'POST',
                    '/post',
                    json: {'hello': 'world'},
                    headers: {'x-session': 'abc'},
                  ),
                ),
                _button('404', () => _request('404', 'GET', '/status/404')),
                _button(
                  'Redirects',
                  () => _request('redirects', 'GET', '/redirect/2'),
                ),
                _button(
                  '/secret',
                  () => _request('secret', 'GET', '/secret/data'),
                ),
                _button('Stats', () => _note('${Bugsee.networkCaptureStats}')),
              ],
            ),
            SwitchListTile(
              key: const Key('filter'),
              title: const Text('Dart filter (drop /secret, hide x-session)'),
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
