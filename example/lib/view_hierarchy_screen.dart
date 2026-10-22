import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/material.dart';

/// What the managed view hierarchy looks like for a screen with ordinary widgets, text the user
/// typed, and a [BugseeSecureView]. The SDK asks the plugin for the Flutter tree when it builds a
/// report; `captureViewHierarchy` asks for one now. The tree has no text: the fields below show
/// text on screen that must never be in it, and the card number sits inside the secure view, where
/// not even the widgets' types are described.
class ViewHierarchyScreen extends StatefulWidget {
  const ViewHierarchyScreen({super.key});

  @override
  State<ViewHierarchyScreen> createState() => _ViewHierarchyScreenState();
}

class _ViewHierarchyScreenState extends State<ViewHierarchyScreen> {
  final _name = TextEditingController(text: 'Jane Doe jane@example.com');
  final _card = TextEditingController(text: '4242 4242 4242 4242');
  String _result = '';

  @override
  void dispose() {
    _name.dispose();
    _card.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    await Bugsee.captureViewHierarchy();
    if (mounted) setState(() => _result = 'captured');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('View hierarchy')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'The Flutter widget tree is sent to the SDK as boxes and type names only.',
            key: Key('vh-text'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('vh-name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name and e-mail',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          BugseeSecureView(
            key: const Key('vh-secure'),
            child: TextField(
              controller: _card,
              decoration: const InputDecoration(
                labelText: 'Card number',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('vh-capture'),
            onPressed: _capture,
            child: const Text('Capture view hierarchy'),
          ),
          if (_result.isNotEmpty) Text(_result),
        ],
      ),
    ),
  );
}
