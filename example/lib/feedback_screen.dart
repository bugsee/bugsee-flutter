import 'dart:async';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_feedback/bugsee_flutter_feedback.dart';
import 'package:flutter/material.dart';

/// The in-app feedback chat (`bugsee_flutter_feedback`, a separate package): show the SDK's native
/// chat screen, set the greeting an empty conversation opens with, and log the messages the
/// listener streams deliver. Launch the SDK on the first tab first: on Android the chat refuses
/// to open before that.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _greeting = TextEditingController(text: 'How can we help?');
  final _log = <String>[];
  StreamSubscription<List<String>>? _received;
  StreamSubscription<String>? _sent;

  @override
  void dispose() {
    _received?.cancel();
    _sent?.cancel();
    _greeting.dispose();
    super.dispose();
  }

  void _note(String line) {
    debugPrint('example: $line');
    if (mounted) setState(() => _log.insert(0, line));
  }

  Future<void> _run(String name, Future<Object?> Function() action) async {
    try {
      _note('$name -> ${await action()}');
    } on BugseeFeedbackException catch (e) {
      _note('$name failed: ${e.reason.name} (${e.message})');
    } on BugseeException catch (e) {
      _note('$name failed: ${e.message}');
    }
  }

  void _toggleListening(bool on) {
    if (on) {
      _received = BugseeFeedback.messagesReceived.listen(
        (messages) => _note('received ${messages.length} message(s)'),
        onError: (Object e) => _note('listener failed: $e'),
      );
      _sent = BugseeFeedback.messageSent.listen(
        (message) => _note('sent a message (${message.length} characters)'),
        onError: (Object e) => _note('listener failed: $e'),
      );
    } else {
      _received?.cancel();
      _sent?.cancel();
      _received = _sent = null;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Feedback chat')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('greeting'),
              controller: _greeting,
              decoration: const InputDecoration(
                labelText: 'Greeting of an empty conversation',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('set-greeting'),
              onPressed: () => _run(
                'setGreeting',
                () => BugseeFeedback.setGreeting(
                  _greeting.text.isEmpty ? null : _greeting.text,
                ),
              ),
              child: const Text('Set greeting'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('show-feedback'),
              onPressed: () => _run('show', BugseeFeedback.show),
              child: const Text('Show the chat'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('feedback-available'),
              onPressed: () => _run('isAvailable', BugseeFeedback.isAvailable),
              child: const Text('Is the module registered?'),
            ),
            SwitchListTile(
              key: const Key('listen'),
              title: const Text('Log messages'),
              value: _received != null,
              onChanged: _toggleListening,
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  for (final line in _log)
                    Text(line, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
